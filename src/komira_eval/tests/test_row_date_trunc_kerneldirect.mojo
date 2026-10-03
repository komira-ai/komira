# =============================================================================
# test_row_date_trunc_kerneldirect.mojo — row-typed date_trunc projection
# VERIFICATION (kernel-direct).
# =============================================================================
#
# VERIFIES the row-typed date_trunc projection arm:
#   * date_trunc(unit FROM temporal) — EXPR_DATE_TRUNC_I64 over a temporal
#     column. The child epoch is read as Int64 (Date32 = i32 days; Date64 =
#     i64 ms); the walker rounds the epoch DOWN to the period start and returns
#     the truncated epoch (still Int64). UNLIKE EXTRACT (which emits an Int
#     FIELD), date_trunc emits a TEMPORAL value — the SAME dtype as the child,
#     so the project walker writes it at the input cell width (Date32 = 4-byte,
#     Date64/Timestamp = 8-byte).
#   * The civil-date machinery (`_ee_civil_from_days` + the new
#     `_ee_days_from_civil` / `_ee_quarter_first_month` / `_ee_mod_floor`)
#     recovers the period-start days and re-multiplies by ticks-per-day.
#   * Sub-unit-remainder proofs: a mid-day timestamp truncated to DAY strips the
#     time-of-day; a timestamp truncated to HOUR strips the minutes/seconds;
#     truncation to MICROSECOND/MILLISECOND on finer units rounds down.
#   * The NARROW-WRITE round-trip: a Date32 trunc output (4-byte int32 cell)
#     written + read back via the same RowBlock primitives the project walker
#     uses (`write_fixed[int32]` / `read_fixed[int32]`) — proves the 4-byte
#     temporal cell write is byte-faithful (an 8-byte int64 write would clobber
#     the adjacent cell).
#
# CONSTRUCTIBILITY: `Expr.date_trunc(unit, child)` builds
# an EXPR_EXTRACT node carrying an EXTRACT_TRUNC_* unit (expr.mojo); the
# COLUMN oracle (the compiler's column evaluator) evaluates it via
# `date_trunc_{date32,ts}`. Fully constructible.
#
# WHY KERNEL-DIRECT (the whole point): `ctx.materialize` / `ctx.read_csv` +
# `collect` compile the full plan dispatch tree, a large comptime instantiation this test
# avoids. It is FULLY
# kernel-direct: hand-build a RowBlock, run the date_trunc evaluator over a
# borrowed `RowCellSource`, assert each output cell vs a HAND-COMPUTED oracle —
# NO `ctx`, NO `read_csv*`, NO `collect`, NO `materialize`.
#
# The seam exercised is the EXACT production project-walker kernel
# (the row-streaming project walker calls this evaluator per
# computed temporal cell):
#   * `ExpressionExecutor._eval_i64_from_source[RowCellSource]`  (DATE_TRUNC_I64)
# over a `RowCellSource` borrowing a hand-built `RowBlock`.
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
    make_date_trunc_i64,
    RT_TRUNC_YEAR,
    RT_TRUNC_QUARTER,
    RT_TRUNC_MONTH,
    RT_TRUNC_WEEK,
    RT_TRUNC_DAY,
    RT_TRUNC_HOUR,
    RT_TRUNC_MINUTE,
    RT_TRUNC_SECOND,
    RT_TRUNC_MILLISECOND,
    RT_TRUNC_MICROSECOND,
)


# =============================================================================
# Fixture: a 2-column input row layout — col0 = Date32 (i32 days) @ 0,
# col1 = Date64 (i64 ms) @ 8, stride 16 (no validity). CELL_DT col0 = I32,
# col1 = I64 (the date backings the cell source reads via read_i64). Mirrors
# the EXTRACT kernel-direct fixture exactly.
# =============================================================================

comptime _OFF_D32: Int = 0
comptime _OFF_D64: Int = 8
comptime _STRIDE: Int = 16

comptime _MS_PER_DAY: Int64 = 86_400_000
comptime _US_PER_DAY: Int64 = 86_400_000_000


def _build_block(d32_days: List[Int32], d64_ms: List[Int64]) raises -> RowBlock:
    var n = len(d32_days)
    var rb = RowBlock.with_capacity(n, 0, _STRIDE)
    for i in range(n):
        rb.write_fixed[DType.int32](i, _OFF_D32, d32_days[i])
        rb.write_fixed[DType.int64](i, _OFF_D64, d64_ms[i])
    rb.set_n_rows(n)
    return rb^


def _offsets() -> List[Int]:
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


# Days-since-1970 anchors (python datetime-verified):
#   2024-07-10 (Wed) -> 19914
#   2024-07-08 (Mon, week start) -> 19912
#   2024-07-01 (month/quarter start) -> 19905
#   2024-01-01 (year start) -> 19723
#   1999-12-31 -> 10956 ; 1999-12-01 -> 10926 ; 1999-10-01 (Q4) -> 10865 ;
#   1999-01-01 -> 10592
comptime _D_2024_07_10: Int32 = 19914
comptime _D_2024_07_08: Int32 = 19912
comptime _D_2024_07_01: Int32 = 19905
comptime _D_2024_01_01: Int32 = 19723
comptime _D_1999_12_31: Int32 = 10956
comptime _D_1999_12_01: Int32 = 10926
comptime _D_1999_10_01: Int32 = 10865
comptime _D_1999_01_01: Int32 = 10592


# =============================================================================
# §1 — date_trunc(YEAR / QUARTER / MONTH / WEEK / DAY FROM Date32). col0 =
# Date32 days, tpd = 1 (the value stays in raw day count). Five roots over col0.
# Input 2024-07-10 (Wed): YEAR -> 2024-01-01, QUARTER -> 2024-07-01 (Q3),
# MONTH -> 2024-07-01, WEEK -> 2024-07-08 (Mon), DAY -> 2024-07-10 (no-op).
# =============================================================================
def test_trunc_calendar_date32() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                                       # 0 col
    pool.append(make_date_trunc_i64(0, RT_TRUNC_YEAR, Int64(1)))     # 1 YEAR
    pool.append(make_date_trunc_i64(0, RT_TRUNC_QUARTER, Int64(1)))  # 2 QUARTER
    pool.append(make_date_trunc_i64(0, RT_TRUNC_MONTH, Int64(1)))    # 3 MONTH
    pool.append(make_date_trunc_i64(0, RT_TRUNC_WEEK, Int64(1)))     # 4 WEEK
    pool.append(make_date_trunc_i64(0, RT_TRUNC_DAY, Int64(1)))      # 5 DAY

    var d32 = List[Int32]()
    d32.append(_D_2024_07_10)   # Wed; year->Jan1, q->Jul1, mo->Jul1, wk->Jul8
    d32.append(_D_1999_12_31)   # year->1999-01-01, q->1999-10-01(Q4), mo->Dec1
    var d64 = List[Int64]()
    for _ in range(len(d32)):
        d64.append(Int64(0))

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    # Row 0: 2024-07-10.
    assert_equal(exec._eval_i64_from_source(cs, 1, 0),
                 Int64(Int(_D_2024_01_01)), "trunc YEAR 2024-07-10")
    assert_equal(exec._eval_i64_from_source(cs, 2, 0),
                 Int64(Int(_D_2024_07_01)), "trunc QUARTER 2024-07-10 (Q3)")
    assert_equal(exec._eval_i64_from_source(cs, 3, 0),
                 Int64(Int(_D_2024_07_01)), "trunc MONTH 2024-07-10")
    assert_equal(exec._eval_i64_from_source(cs, 4, 0),
                 Int64(Int(_D_2024_07_08)), "trunc WEEK 2024-07-10 (Mon)")
    assert_equal(exec._eval_i64_from_source(cs, 5, 0),
                 Int64(Int(_D_2024_07_10)), "trunc DAY 2024-07-10 (no-op)")

    # Row 1: 1999-12-31.
    assert_equal(exec._eval_i64_from_source(cs, 1, 1),
                 Int64(Int(_D_1999_01_01)), "trunc YEAR 1999-12-31")
    assert_equal(exec._eval_i64_from_source(cs, 2, 1),
                 Int64(Int(_D_1999_10_01)), "trunc QUARTER 1999-12-31 (Q4)")
    assert_equal(exec._eval_i64_from_source(cs, 3, 1),
                 Int64(Int(_D_1999_12_01)), "trunc MONTH 1999-12-31")


# =============================================================================
# §2 — date_trunc(MONTH / DAY FROM Date64-ms). col1 = Date64 ms (tpd = ms/day).
# Output stays in ms (same unit). Proves the calendar-trunc reconstructs the
# epoch as days*tpd and strips the sub-day portion.
#
# Input: 2024-07-10 at 13:37:42.500 (= ms-since-epoch + sub-day offset).
#   MONTH -> 2024-07-01 00:00:00.000 = 19905 * 86400000 ms
#   DAY   -> 2024-07-10 00:00:00.000 = 19914 * 86400000 ms (strips time)
# =============================================================================
def test_trunc_date64_ms_subday_strip() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(1))                                          # 0 Date64
    pool.append(make_date_trunc_i64(0, RT_TRUNC_MONTH, _MS_PER_DAY))  # 1 MONTH
    pool.append(make_date_trunc_i64(0, RT_TRUNC_DAY, _MS_PER_DAY))    # 2 DAY

    var secs_of_day = Int64(13) * 3600 + Int64(37) * 60 + Int64(42)
    var sub_day_ms = secs_of_day * 1000 + Int64(500)
    var ms = Int64(Int(_D_2024_07_10)) * _MS_PER_DAY + sub_day_ms

    var d32 = List[Int32]()
    var d64 = List[Int64]()
    d32.append(Int32(0))
    d64.append(ms)

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    var want_month = Int64(Int(_D_2024_07_01)) * _MS_PER_DAY
    var want_day = Int64(Int(_D_2024_07_10)) * _MS_PER_DAY
    assert_equal(exec._eval_i64_from_source(cs, 1, 0), want_month,
                 "Date64 trunc MONTH (strips sub-day)")
    assert_equal(exec._eval_i64_from_source(cs, 2, 0), want_day,
                 "Date64 trunc DAY (strips time-of-day)")


# =============================================================================
# §3 — date_trunc(HOUR / MINUTE / SECOND FROM Date64-ms). SUB-UNIT-REMAINDER
# PROOF: a timestamp with a non-zero sub-unit portion truncates correctly.
# Input: 2024-07-10 13:37:42.500.
#   HOUR   -> 13:00:00.000 (strips 37m42s500ms)
#   MINUTE -> 13:37:00.000 (strips 42s500ms)
#   SECOND -> 13:37:42.000 (strips 500ms)
# =============================================================================
def test_trunc_date64_clock_remainder() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(1))                                          # 0 Date64
    pool.append(make_date_trunc_i64(0, RT_TRUNC_HOUR, _MS_PER_DAY))   # 1 HOUR
    pool.append(make_date_trunc_i64(0, RT_TRUNC_MINUTE, _MS_PER_DAY)) # 2 MINUTE
    pool.append(make_date_trunc_i64(0, RT_TRUNC_SECOND, _MS_PER_DAY)) # 3 SECOND

    var day_ms = Int64(Int(_D_2024_07_10)) * _MS_PER_DAY
    var h = Int64(13)
    var mi = Int64(37)
    var s = Int64(42)
    var ms_frac = Int64(500)
    var ts = (
        day_ms + h * Int64(3_600_000) + mi * Int64(60_000)
        + s * Int64(1_000) + ms_frac
    )

    var d32 = List[Int32]()
    var d64 = List[Int64]()
    d32.append(Int32(0))
    d64.append(ts)

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    var want_hour = day_ms + h * Int64(3_600_000)
    var want_min = day_ms + h * Int64(3_600_000) + mi * Int64(60_000)
    var want_sec = (
        day_ms + h * Int64(3_600_000) + mi * Int64(60_000) + s * Int64(1_000)
    )
    assert_equal(exec._eval_i64_from_source(cs, 1, 0), want_hour,
                 "trunc HOUR (strips 37m42.5s)")
    assert_equal(exec._eval_i64_from_source(cs, 2, 0), want_min,
                 "trunc MINUTE (strips 42.5s)")
    assert_equal(exec._eval_i64_from_source(cs, 3, 0), want_sec,
                 "trunc SECOND (strips 500ms)")


# =============================================================================
# §4 — date_trunc(MILLISECOND / MICROSECOND FROM Timestamp-us). col1 reused as
# a us-since-epoch column (tpd = us/day). MILLISECOND rounds down to the ms
# boundary (strips sub-ms us); MICROSECOND is a no-op for us-resolution input.
# Input: 2024-07-10 00:00:01.234_567 (1 sec + 234ms + 567us).
#   MILLISECOND -> 00:00:01.234_000  (strips 567 us)
#   MICROSECOND -> 00:00:01.234_567  (no-op at us resolution)
# =============================================================================
def test_trunc_us_millisecond() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(1))                                              # 0 col
    pool.append(make_date_trunc_i64(0, RT_TRUNC_MILLISECOND, _US_PER_DAY))  # 1 MS
    pool.append(make_date_trunc_i64(0, RT_TRUNC_MICROSECOND, _US_PER_DAY))  # 2 US

    var day_us = Int64(Int(_D_2024_07_10)) * _US_PER_DAY
    # 1 second + 234_567 microseconds.
    var us = day_us + Int64(1_000_000) + Int64(234_567)

    var d32 = List[Int32]()
    var d64 = List[Int64]()
    d32.append(Int32(0))
    d64.append(us)

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    # MS boundary: strip the trailing 567 us -> ...234_000.
    var want_ms = day_us + Int64(1_000_000) + Int64(234_000)
    assert_equal(exec._eval_i64_from_source(cs, 1, 0), want_ms,
                 "trunc MILLISECOND (strips sub-ms us)")
    # US no-op at us resolution.
    assert_equal(exec._eval_i64_from_source(cs, 2, 0), us,
                 "trunc MICROSECOND (no-op at us)")


# =============================================================================
# §5 — NARROW-WRITE round-trip. The project walker writes a Date32 trunc output
# as a 4-byte int32 cell (`write_fixed[int32](Int32(Int(v)))`); an 8-byte int64
# write would clobber the next cell. Verify the truncated Date32 epoch round-
# trips through the SAME RowBlock primitives the walker uses, AND that the
# adjacent cell is untouched (a 4-byte write does not bleed into bytes [4,8)).
# =============================================================================
def test_narrow_date32_write_roundtrip() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                                       # 0 col
    pool.append(make_date_trunc_i64(0, RT_TRUNC_MONTH, Int64(1)))  # 1 MONTH ROOT

    var d32 = List[Int32]()
    var d64 = List[Int64]()
    d32.append(_D_2024_07_10)
    d64.append(Int64(0))

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    var truncated = exec._eval_i64_from_source(cs, 1, 0)  # = 19905
    assert_equal(truncated, Int64(Int(_D_2024_07_01)),
                 "trunc MONTH value before narrow write")

    # Simulate the walker's narrow (4-byte) temporal cell write into a fresh
    # output block: a Date32 output cell @ 0 (4-byte) followed by a sentinel
    # 4-byte cell @ 4 that MUST remain intact (the 8-byte-write bug would zero
    # its low bytes).
    var out = RowBlock.with_capacity(1, 0, 8)
    var sentinel = Int32(0x7EADBEEF)
    out.write_fixed[DType.int32](0, 4, sentinel)        # adjacent cell first
    out.write_fixed[DType.int32](0, 0, Int32(Int(truncated)))  # 4-byte trunc
    out.set_n_rows(1)

    var back = out.read_fixed[DType.int32](0, 0)
    assert_equal(Int64(Int(back)), Int64(Int(_D_2024_07_01)),
                 "Date32 trunc 4-byte cell round-trips")
    var adj = out.read_fixed[DType.int32](0, 4)
    assert_true(adj == sentinel,
                "4-byte trunc write did NOT clobber the adjacent cell")


def main() raises:
    var suite = TestSuite()
    suite.test[test_trunc_calendar_date32]()
    suite.test[test_trunc_date64_ms_subday_strip]()
    suite.test[test_trunc_date64_clock_remainder]()
    suite.test[test_trunc_us_millisecond]()
    suite.test[test_narrow_date32_write_roundtrip]()
    suite^.run()
