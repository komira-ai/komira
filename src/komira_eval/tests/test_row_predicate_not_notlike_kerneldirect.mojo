# =============================================================================
# test_row_predicate_not_notlike_kerneldirect.mojo — row-typed NOT (unary
# boolean negation) + NOT LIKE predicate VERIFICATION (kernel-direct).
# =============================================================================
#
# VERIFIES the row-typed FILTER predicate arms:
#   * NOT <bool> — EXPR_NOT_BOOL over any walker-servable bool child. The
#     per-cell walker recurses on the child and negates the scalar Bool, with
#     3VL: when the child references a NULL operand cell the predicate result is
#     SQL-NULL and the row is EXCLUDED from a WHERE (the NOT arm returns False).
#   * NOT LIKE — `NOT(col LIKE 'pat')` = the unary-NOT wrapper over the
#     already-served EXPR_LIKE_STRING arm; comes for free with NOT.
#
# CONSTRUCTIBILITY: NOT is constructible (UN_NOT=0 + `~pred` via
# Column.__invert__ / Expr.unary). NOT LIKE = NOT(LIKE) (no STR_NOT_LIKE op;
# LIKE self-serves so the unary-NOT wraps it). ILIKE / regexp-NOT are NOT
# constructible as a row-walker shape here (ILIKE has no STR_ILIKE op; regexp is
# the EXPR_REGEXP family routed column-side) — flagged, not implemented.
#
# WHY KERNEL-DIRECT (the whole point):
# ------------------------------------
# `ctx.materialize` / `ctx.read_csv` + `collect` compile the full plan dispatch tree, a large comptime instantiation this test
# avoids. It is FULLY kernel-direct: hand-build a RowBlock, run
# the bool evaluator over a borrowed `RowCellSource`, assert the selected rows
# vs a HAND-computed oracle — NO `ctx`, NO `read_csv*`, NO `collect`, NO
# `materialize`.
#
# The seam exercised is the EXACT production filter-walker kernel
# (the row-streaming filter walker calls this evaluator per row):
#   * `ExpressionExecutor._eval_bool_from_source[RowCellSource]`
# over a `RowCellSource` borrowing a hand-built `RowBlock`.
#
# Encapsulation: NO UnsafePointer / wildcard origins /
# unsafe_from_address / take_pointee. eval surface only. `fn` style.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_eval.row_format import RowBlock
from komira_eval.cell_source import (
    RowCellSource,
    CELL_DT_I64,
    CELL_DT_STRING,
)
from komira_eval.expression_executor import ExpressionExecutor
from komira_eval.runtime_expr import (
    RuntimeExpr,
    make_col,
    make_lit_i64,
    make_gt_i64,
    make_eq_i64,
    make_not_bool,
    make_and,
    make_or,
    make_col_string,
    make_lit_string,
    make_like_string,
)


# =============================================================================
# Fixture A: a single I64 column — col0 @ 0, stride 8 (no validity).
# =============================================================================

comptime _OFF0: Int = 0
comptime _STRIDE_1I64: Int = 8


def _build_i64_block(vals: List[Int64]) raises -> RowBlock:
    var n = len(vals)
    var rb = RowBlock.with_capacity(n, 0, _STRIDE_1I64)
    for i in range(n):
        rb.write_fixed[DType.int64](i, _OFF0, vals[i])
    rb.set_n_rows(n)
    return rb^


def _i64_offsets() -> List[Int]:
    var offs = List[Int]()
    offs.append(_OFF0)
    return offs^


def _i64_dtypes() -> List[UInt8]:
    var dts = List[UInt8]()
    dts.append(CELL_DT_I64)
    return dts^


# =============================================================================
# §1 — NOT (x > 5). Pool:
#   0: EXPR_COL(col0)
#   1: EXPR_LIT_I64(5)
#   2: EXPR_GT_I64(0, 1)
#   3: EXPR_NOT_BOOL(2)   ROOT
# Oracle: row selected iff NOT(x > 5) == (x <= 5).
# =============================================================================
def test_not_gt() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))           # 0
    pool.append(make_lit_i64(5))       # 1
    pool.append(make_gt_i64(0, 1))     # 2
    pool.append(make_not_bool(2))      # 3 ROOT

    var vals = List[Int64]()
    vals.append(3); vals.append(5); vals.append(6); vals.append(10)
    vals.append(-1)

    var rb = _build_i64_block(vals)
    var cs = RowCellSource(rb, _i64_offsets(), _i64_dtypes())
    var exec = ExpressionExecutor(pool^, 3, List[String]())

    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 3, r)
        var want = not (vals[r] > 5)  # x <= 5
        assert_equal(
            got, want,
            "NOT(x>5) row " + String(r) + " (x=" + String(vals[r]) + ")",
        )


# =============================================================================
# §2 — NOT (x = 5). Pool:
#   0: EXPR_COL(col0)
#   1: EXPR_LIT_I64(5)
#   2: EXPR_EQ_I64(0, 1)
#   3: EXPR_NOT_BOOL(2)   ROOT
# Oracle: row selected iff x != 5.
# =============================================================================
def test_not_eq() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))           # 0
    pool.append(make_lit_i64(5))       # 1
    pool.append(make_eq_i64(0, 1))     # 2
    pool.append(make_not_bool(2))      # 3 ROOT

    var vals = List[Int64]()
    vals.append(5); vals.append(4); vals.append(5); vals.append(0)

    var rb = _build_i64_block(vals)
    var cs = RowCellSource(rb, _i64_offsets(), _i64_dtypes())
    var exec = ExpressionExecutor(pool^, 3, List[String]())

    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 3, r)
        var want = vals[r] != 5
        assert_equal(
            got, want,
            "NOT(x=5) row " + String(r) + " (x=" + String(vals[r]) + ")",
        )


# =============================================================================
# §3 — NOT (a AND b). De-Morgan check via the walker (no rewrite — the walker
# recurses on the AND and negates the conjunction).
#   a := (x > 5), b := (x < 20)
#   0: EXPR_COL(col0)  1: EXPR_LIT_I64(5)  2: EXPR_GT_I64(0,1)  (a)
#   3: EXPR_LIT_I64(20) 4: EXPR_LT_I64(0,3) (b)
#   5: EXPR_AND(2,4)    6: EXPR_NOT_BOOL(5)  ROOT
# Oracle: NOT(a AND b) == (x <= 5) OR (x >= 20).
# =============================================================================
def test_not_and() raises:
    from komira_eval.runtime_expr import make_lt_i64
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))            # 0
    pool.append(make_lit_i64(5))        # 1
    pool.append(make_gt_i64(0, 1))      # 2  a = x>5
    pool.append(make_lit_i64(20))       # 3
    pool.append(make_lt_i64(0, 3))      # 4  b = x<20
    pool.append(make_and(2, 4))         # 5  a AND b
    pool.append(make_not_bool(5))       # 6  ROOT

    var vals = List[Int64]()
    vals.append(3); vals.append(10); vals.append(20); vals.append(25)
    vals.append(5)

    var rb = _build_i64_block(vals)
    var cs = RowCellSource(rb, _i64_offsets(), _i64_dtypes())
    var exec = ExpressionExecutor(pool^, 6, List[String]())

    for r in range(rb.n_rows):
        var x = vals[r]
        var got = exec._eval_bool_from_source(cs, 6, r)
        var want = (x <= 5) or (x >= 20)  # De-Morgan of (x>5 AND x<20)
        assert_equal(
            got, want,
            "NOT(a AND b) row " + String(r) + " (x=" + String(x) + ")",
        )


# =============================================================================
# §4 — 3VL: NOT (nullcol > 5). col0 is nullable; NULL rows must be EXCLUDED
# (NOT NULL = NULL, dropped from a WHERE). Builds a RowBlock with a validity
# bitmap region after the single i64 cell (stride = 8 + 1 validity byte).
#   0: EXPR_COL(col0)  1: EXPR_LIT_I64(5)  2: EXPR_GT_I64(0,1)  3: NOT(2) ROOT
# Oracle: NULL row -> excluded; present row -> (x <= 5).
# =============================================================================
comptime _VAL_OFF: Int = 8           # validity bitmap after the i64 cell
comptime _STRIDE_NULLABLE: Int = 9   # 8 (i64) + 1 (validity byte for 1 col)


def test_not_gt_3vl_null() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))           # 0
    pool.append(make_lit_i64(5))       # 1
    pool.append(make_gt_i64(0, 1))     # 2
    pool.append(make_not_bool(2))      # 3 ROOT

    # values; rows 1 and 3 are NULL. The NULL rows' RAW stored value is 3 (<=5)
    # so that a NON-3VL `not(x>5)` would WRONGLY include them (not(3>5)=True);
    # the 3VL exclusion is the only thing that drops them. This makes the test
    # distinguish 3VL-correct from a plain raw negation.
    var vals = List[Int64]()
    vals.append(3); vals.append(3); vals.append(8); vals.append(3)
    vals.append(5)
    var is_null = List[Bool]()
    is_null.append(False); is_null.append(True); is_null.append(False)
    is_null.append(True); is_null.append(False)

    var n = len(vals)
    var rb = RowBlock.with_capacity(n, 0, _STRIDE_NULLABLE)
    for i in range(n):
        rb.write_fixed[DType.int64](i, _OFF0, vals[i])
        if is_null[i]:
            rb.set_cell_null(i, _VAL_OFF, 0)
    rb.set_n_rows(n)

    var cs = RowCellSource(
        rb, _i64_offsets(), _i64_dtypes(),
        has_validity=True, validity_offset=_VAL_OFF,
    )
    var exec = ExpressionExecutor(pool^, 3, List[String]())

    for r in range(n):
        var got = exec._eval_bool_from_source(cs, 3, r)
        # 3VL: NULL operand -> NOT NULL = NULL -> excluded (False); else x<=5.
        var want = False if is_null[r] else (vals[r] <= 5)
        assert_equal(
            got, want,
            "NOT(nullcol>5) row " + String(r)
            + " null=" + String(is_null[r]) + " x=" + String(vals[r]),
        )


# =============================================================================
# Fixture B: a single STRING column — col0 @ 0, stride 8 (var-string slot
# descriptor). Built via RowBlock string write API.
# =============================================================================

comptime _SOFF0: Int = 0
comptime _SSTRIDE: Int = 8


def _string_offsets() -> List[Int]:
    var offs = List[Int]()
    offs.append(_SOFF0)
    return offs^


def _string_dtypes() -> List[UInt8]:
    var dts = List[UInt8]()
    dts.append(CELL_DT_STRING)
    return dts^


# =============================================================================
# §5 — x NOT LIKE 'a%' = NOT(LIKE). col0 STRING.
#   0: EXPR_COL_STRING(col0)
#   1: EXPR_LIT_STRING(pool 0 = "a%")
#   2: EXPR_LIKE_STRING(0, 1)
#   3: EXPR_NOT_BOOL(2)   ROOT
# Oracle: row selected iff NOT (value LIKE 'a%') == value does NOT start 'a'.
# =============================================================================
def test_not_like() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(0))    # 0
    pool.append(make_lit_string(0))    # 1 -> string_pool[0] = "a%"
    pool.append(make_like_string(0, 1))  # 2
    pool.append(make_not_bool(2))      # 3 ROOT

    var spool = List[String]()
    spool.append("a%")

    var vals = List[String]()
    vals.append("apple"); vals.append("banana"); vals.append("avocado")
    vals.append("cherry"); vals.append("a")

    var n = len(vals)
    var rb = RowBlock.with_capacity(n, n * 16, _SSTRIDE)
    for i in range(n):
        rb.write_var_string_cell(i, _SOFF0, vals[i].as_bytes())
    rb.set_n_rows(n)

    var cs = RowCellSource(rb, _string_offsets(), _string_dtypes())
    var exec = ExpressionExecutor(pool^, 3, List[String](), spool^)

    for r in range(n):
        var got = exec._eval_bool_from_source(cs, 3, r)
        # 'a%' matches values starting with 'a'; NOT LIKE selects the rest.
        var starts_a = vals[r].startswith("a")
        var want = not starts_a
        assert_equal(
            got, want,
            "x NOT LIKE 'a%' row " + String(r) + " (val=" + vals[r] + ")",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_not_gt]()
    suite.test[test_not_eq]()
    suite.test[test_not_and]()
    suite.test[test_not_gt_3vl_null]()
    suite.test[test_not_like]()
    suite^.run()
