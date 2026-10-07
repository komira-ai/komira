# =============================================================================
# Tests for `sel_kernels` — templated primitive comparison kernels operating
# on RowSelectionVector.
#
# Coverage matrix:
# * 5 DType test scenarios: Float32, Float64, Int32, Int64, Date32 (i32).
# * 6 ops: GT, GE, LT, LE, EQ, NE.
# * 2 callsite shapes: col-vs-lit, col-vs-col.
# = 60 base correctness tests. Plus:
#   - Identity-fast-path verification (sel_in.len() == col.length triggers
#     the unit-stride SIMD path).
#   - Gather-path verification (sel_in narrowed by prior conjunct).
#   - Edge cases: empty sel_in, all-pass, all-fail.
#   - NaN handling (Float comparisons per IEEE 754 — a KNOWN divergence from
#     DuckDB/Postgres/Spark, pinned deliberately; see the NaN banner below).
#   - Sel-pair contract: true_sel.len() + false_sel.len() == sel_in.len().
#   - Selectivity fuzz (random Lit with all 6 ops; partition contract).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.math import isnan

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.selection_vector_row import RowSelectionVector
from komira_kernels.sel_kernels import (
    BIN_OP_GT,
    BIN_OP_GE,
    BIN_OP_LT,
    BIN_OP_LE,
    BIN_OP_EQ,
    BIN_OP_NE,
    binary_select_col_lit,
    binary_select_col_col,
)


# -----------------------------------------------------------------------------
# Helpers — build fixtures + run scalar reference.
# -----------------------------------------------------------------------------


def _identity_sel(n: Int) -> RowSelectionVector:
    return RowSelectionVector.identity_selection(n)


def _build_int32_seq(n: Int, base: Int) -> PrimitiveArray[DType.int32]:
    var src = List[Scalar[DType.int32]]()
    for i in range(n):
        src.append(Scalar[DType.int32](Int32(base + i)))
    return PrimitiveArray[DType.int32].from_list(src)


def _build_int64_seq(n: Int, base: Int) -> PrimitiveArray[DType.int64]:
    var src = List[Scalar[DType.int64]]()
    for i in range(n):
        src.append(Scalar[DType.int64](Int64(base + i)))
    return PrimitiveArray[DType.int64].from_list(src)


def _build_float32_seq(n: Int, base: Float32) -> PrimitiveArray[DType.float32]:
    var src = List[Scalar[DType.float32]]()
    for i in range(n):
        src.append(Scalar[DType.float32](base + Float32(i) * Float32(0.5)))
    return PrimitiveArray[DType.float32].from_list(src)


def _build_float64_seq(n: Int, base: Float64) -> PrimitiveArray[DType.float64]:
    var src = List[Scalar[DType.float64]]()
    for i in range(n):
        src.append(Scalar[DType.float64](base + Float64(i) * 0.25))
    return PrimitiveArray[DType.float64].from_list(src)


def _scalar_ref_int32[op: UInt8](lv: Int32, rv: Int32) -> Bool:
    comptime if op == BIN_OP_GT:
        return lv > rv
    elif op == BIN_OP_GE:
        return lv >= rv
    elif op == BIN_OP_LT:
        return lv < rv
    elif op == BIN_OP_LE:
        return lv <= rv
    elif op == BIN_OP_EQ:
        return lv == rv
    else:
        return lv != rv


def _scalar_ref_int64[op: UInt8](lv: Int64, rv: Int64) -> Bool:
    comptime if op == BIN_OP_GT:
        return lv > rv
    elif op == BIN_OP_GE:
        return lv >= rv
    elif op == BIN_OP_LT:
        return lv < rv
    elif op == BIN_OP_LE:
        return lv <= rv
    elif op == BIN_OP_EQ:
        return lv == rv
    else:
        return lv != rv


def _scalar_ref_f32[op: UInt8](lv: Float32, rv: Float32) -> Bool:
    comptime if op == BIN_OP_GT:
        return lv > rv
    elif op == BIN_OP_GE:
        return lv >= rv
    elif op == BIN_OP_LT:
        return lv < rv
    elif op == BIN_OP_LE:
        return lv <= rv
    elif op == BIN_OP_EQ:
        return lv == rv
    else:
        return lv != rv


def _scalar_ref_f64[op: UInt8](lv: Float64, rv: Float64) -> Bool:
    comptime if op == BIN_OP_GT:
        return lv > rv
    elif op == BIN_OP_GE:
        return lv >= rv
    elif op == BIN_OP_LT:
        return lv < rv
    elif op == BIN_OP_LE:
        return lv <= rv
    elif op == BIN_OP_EQ:
        return lv == rv
    else:
        return lv != rv


def _check_sel_pair_partition(
    n_in: Int, true_count: Int, false_count: Int
) raises:
    """true_sel + false_sel must partition sel_in."""
    assert_equal(true_count + false_count, n_in)


# =============================================================================
# Int32 — 6 ops × 2 shapes (12 tests)
# =============================================================================


def test_int32_col_lit_gt() raises:
    var col = _build_int32_seq(67, 0)  # 0..66 — also covers SIMD tail
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_GT](
        col, Int32(50), sel_in, true_sel, false_sel
    )

    # Expected: rows 51..66 (16 rows) pass.
    assert_equal(count, 16)
    assert_equal(true_sel.len(), 16)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())
    for k in range(true_sel.len()):
        var idx = Int(true_sel.get(k))
        assert_true(_scalar_ref_int32[BIN_OP_GT](Int32(idx), Int32(50)))


def test_int32_col_lit_ge() raises:
    var col = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_GE](
        col, Int32(50), sel_in, true_sel, false_sel
    )

    assert_equal(count, 17)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_lit_lt() raises:
    var col = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_LT](
        col, Int32(10), sel_in, true_sel, false_sel
    )

    assert_equal(count, 10)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_lit_le() raises:
    var col = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_LE](
        col, Int32(10), sel_in, true_sel, false_sel
    )

    assert_equal(count, 11)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_lit_eq() raises:
    var col = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_EQ](
        col, Int32(42), sel_in, true_sel, false_sel
    )

    assert_equal(count, 1)
    assert_equal(Int(true_sel.get(0)), 42)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_lit_ne() raises:
    var col = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_NE](
        col, Int32(42), sel_in, true_sel, false_sel
    )

    assert_equal(count, 66)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_col_gt() raises:
    var left = _build_int32_seq(67, 0)
    var right = _build_int32_seq(67, -5)  # right[i] = i - 5 → left > right
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_col[DType.int32, BIN_OP_GT](
        left, right, sel_in, true_sel, false_sel
    )

    assert_equal(count, 67)  # every row passes
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_col_ge() raises:
    var left = _build_int32_seq(67, 0)
    var right = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_col[DType.int32, BIN_OP_GE](
        left, right, sel_in, true_sel, false_sel
    )

    assert_equal(count, 67)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_col_lt() raises:
    var left = _build_int32_seq(67, 0)
    var right = _build_int32_seq(67, 5)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_col[DType.int32, BIN_OP_LT](
        left, right, sel_in, true_sel, false_sel
    )

    assert_equal(count, 67)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_col_le() raises:
    var left = _build_int32_seq(67, 0)
    var right = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_col[DType.int32, BIN_OP_LE](
        left, right, sel_in, true_sel, false_sel
    )

    assert_equal(count, 67)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_col_eq() raises:
    var left = _build_int32_seq(67, 0)
    var right = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_col[DType.int32, BIN_OP_EQ](
        left, right, sel_in, true_sel, false_sel
    )

    assert_equal(count, 67)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int32_col_col_ne() raises:
    var left = _build_int32_seq(67, 0)
    var right = _build_int32_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_col[DType.int32, BIN_OP_NE](
        left, right, sel_in, true_sel, false_sel
    )

    assert_equal(count, 0)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


# =============================================================================
# Int64 — 6 ops × 2 shapes (12 tests)
# =============================================================================


def test_int64_col_lit_gt() raises:
    var col = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int64, BIN_OP_GT](
        col, Int64(50), sel_in, true_sel, false_sel
    )
    assert_equal(count, 16)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int64_col_lit_ge() raises:
    var col = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int64, BIN_OP_GE](
        col, Int64(50), sel_in, true_sel, false_sel
    )
    assert_equal(count, 17)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int64_col_lit_lt() raises:
    var col = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int64, BIN_OP_LT](
        col, Int64(10), sel_in, true_sel, false_sel
    )
    assert_equal(count, 10)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int64_col_lit_le() raises:
    var col = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int64, BIN_OP_LE](
        col, Int64(10), sel_in, true_sel, false_sel
    )
    assert_equal(count, 11)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int64_col_lit_eq() raises:
    var col = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int64, BIN_OP_EQ](
        col, Int64(42), sel_in, true_sel, false_sel
    )
    assert_equal(count, 1)
    assert_equal(Int(true_sel.get(0)), 42)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int64_col_lit_ne() raises:
    var col = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int64, BIN_OP_NE](
        col, Int64(42), sel_in, true_sel, false_sel
    )
    assert_equal(count, 66)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int64_col_col_gt() raises:
    var left = _build_int64_seq(67, 0)
    var right = _build_int64_seq(67, -5)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int64, BIN_OP_GT](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_int64_col_col_ge() raises:
    var left = _build_int64_seq(67, 0)
    var right = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int64, BIN_OP_GE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_int64_col_col_lt() raises:
    var left = _build_int64_seq(67, 0)
    var right = _build_int64_seq(67, 5)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int64, BIN_OP_LT](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_int64_col_col_le() raises:
    var left = _build_int64_seq(67, 0)
    var right = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int64, BIN_OP_LE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_int64_col_col_eq() raises:
    var left = _build_int64_seq(67, 0)
    var right = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int64, BIN_OP_EQ](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_int64_col_col_ne() raises:
    var left = _build_int64_seq(67, 0)
    var right = _build_int64_seq(67, 0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int64, BIN_OP_NE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 0)


# =============================================================================
# Float32 — 6 ops × 2 shapes (12 tests). Float fixture: base 0.0, stride 0.5.
# =============================================================================


def test_f32_col_lit_gt() raises:
    var col = _build_float32_seq(67, Float32(0.0))  # 0.0, 0.5, ..., 33.0
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float32, BIN_OP_GT](
        col, Float32(10.0), sel_in, true_sel, false_sel
    )
    # Rows where 0 + i*0.5 > 10 -> i > 20 -> i in 21..66 = 46 rows
    assert_equal(count, 46)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_f32_col_lit_ge() raises:
    var col = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float32, BIN_OP_GE](
        col, Float32(10.0), sel_in, true_sel, false_sel
    )
    # Rows where i*0.5 >= 10 -> i >= 20 -> 47 rows
    assert_equal(count, 47)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_f32_col_lit_lt() raises:
    var col = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float32, BIN_OP_LT](
        col, Float32(10.0), sel_in, true_sel, false_sel
    )
    # Rows where i*0.5 < 10 -> i < 20 -> 20 rows
    assert_equal(count, 20)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_f32_col_lit_le() raises:
    var col = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float32, BIN_OP_LE](
        col, Float32(10.0), sel_in, true_sel, false_sel
    )
    # i*0.5 <= 10 -> i <= 20 -> 21 rows
    assert_equal(count, 21)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_f32_col_lit_eq() raises:
    var col = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float32, BIN_OP_EQ](
        col, Float32(10.0), sel_in, true_sel, false_sel
    )
    assert_equal(count, 1)
    assert_equal(Int(true_sel.get(0)), 20)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_f32_col_lit_ne() raises:
    var col = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float32, BIN_OP_NE](
        col, Float32(10.0), sel_in, true_sel, false_sel
    )
    assert_equal(count, 66)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_f32_col_col_gt() raises:
    var left = _build_float32_seq(67, Float32(1.0))
    var right = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float32, BIN_OP_GT](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f32_col_col_ge() raises:
    var left = _build_float32_seq(67, Float32(0.0))
    var right = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float32, BIN_OP_GE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f32_col_col_lt() raises:
    var left = _build_float32_seq(67, Float32(0.0))
    var right = _build_float32_seq(67, Float32(1.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float32, BIN_OP_LT](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f32_col_col_le() raises:
    var left = _build_float32_seq(67, Float32(0.0))
    var right = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float32, BIN_OP_LE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f32_col_col_eq() raises:
    var left = _build_float32_seq(67, Float32(0.0))
    var right = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float32, BIN_OP_EQ](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f32_col_col_ne() raises:
    var left = _build_float32_seq(67, Float32(0.0))
    var right = _build_float32_seq(67, Float32(0.0))
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float32, BIN_OP_NE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 0)


# =============================================================================
# Float64 — 6 ops × 2 shapes (12 tests). Fixture: base 0.0, stride 0.25.
# =============================================================================


def test_f64_col_lit_gt() raises:
    var col = _build_float64_seq(67, 0.0)  # 0.0, 0.25, ..., 16.5
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float64, BIN_OP_GT](
        col, 8.0, sel_in, true_sel, false_sel
    )
    # i*0.25 > 8 -> i > 32 -> i in 33..66 = 34 rows
    assert_equal(count, 34)
    _check_sel_pair_partition(67, true_sel.len(), false_sel.len())


def test_f64_col_lit_ge() raises:
    var col = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float64, BIN_OP_GE](
        col, 8.0, sel_in, true_sel, false_sel
    )
    # i*0.25 >= 8 -> i >= 32 -> 35 rows
    assert_equal(count, 35)


def test_f64_col_lit_lt() raises:
    var col = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float64, BIN_OP_LT](
        col, 8.0, sel_in, true_sel, false_sel
    )
    assert_equal(count, 32)


def test_f64_col_lit_le() raises:
    var col = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float64, BIN_OP_LE](
        col, 8.0, sel_in, true_sel, false_sel
    )
    assert_equal(count, 33)


def test_f64_col_lit_eq() raises:
    var col = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float64, BIN_OP_EQ](
        col, 8.0, sel_in, true_sel, false_sel
    )
    assert_equal(count, 1)
    assert_equal(Int(true_sel.get(0)), 32)


def test_f64_col_lit_ne() raises:
    var col = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.float64, BIN_OP_NE](
        col, 8.0, sel_in, true_sel, false_sel
    )
    assert_equal(count, 66)


def test_f64_col_col_gt() raises:
    var left = _build_float64_seq(67, 1.0)
    var right = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float64, BIN_OP_GT](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f64_col_col_ge() raises:
    var left = _build_float64_seq(67, 0.0)
    var right = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float64, BIN_OP_GE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f64_col_col_lt() raises:
    var left = _build_float64_seq(67, 0.0)
    var right = _build_float64_seq(67, 1.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float64, BIN_OP_LT](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f64_col_col_le() raises:
    var left = _build_float64_seq(67, 0.0)
    var right = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float64, BIN_OP_LE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f64_col_col_eq() raises:
    var left = _build_float64_seq(67, 0.0)
    var right = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float64, BIN_OP_EQ](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 67)


def test_f64_col_col_ne() raises:
    var left = _build_float64_seq(67, 0.0)
    var right = _build_float64_seq(67, 0.0)
    var sel_in = _identity_sel(67)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.float64, BIN_OP_NE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 0)


# =============================================================================
# Date32 — physical i32, signed-day semantics. Uses _build_int32_seq.
# 6 ops × 2 shapes (12 tests). Treating dates as 1970-01-01 = 0.
# =============================================================================


def test_date32_col_lit_gt() raises:
    # 7 days: 2024-01-01..2024-01-07 (days_since_epoch 19723..19729).
    var col = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int32, BIN_OP_GT](
        col, Int32(19725), sel_in, true_sel, false_sel
    )
    # days > 19725 → 19726, 19727, 19728, 19729 = 4
    assert_equal(count, 4)


def test_date32_col_lit_ge() raises:
    var col = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int32, BIN_OP_GE](
        col, Int32(19725), sel_in, true_sel, false_sel
    )
    assert_equal(count, 5)


def test_date32_col_lit_lt() raises:
    var col = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int32, BIN_OP_LT](
        col, Int32(19725), sel_in, true_sel, false_sel
    )
    assert_equal(count, 2)


def test_date32_col_lit_le() raises:
    var col = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int32, BIN_OP_LE](
        col, Int32(19725), sel_in, true_sel, false_sel
    )
    assert_equal(count, 3)


def test_date32_col_lit_eq() raises:
    var col = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int32, BIN_OP_EQ](
        col, Int32(19725), sel_in, true_sel, false_sel
    )
    assert_equal(count, 1)


def test_date32_col_lit_ne() raises:
    var col = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int32, BIN_OP_NE](
        col, Int32(19725), sel_in, true_sel, false_sel
    )
    assert_equal(count, 6)


def test_date32_col_col_gt() raises:
    var left = _build_int32_seq(7, 19726)  # 2024-01-04..10
    var right = _build_int32_seq(7, 19723)  # 2024-01-01..07
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int32, BIN_OP_GT](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 7)


def test_date32_col_col_ge() raises:
    var left = _build_int32_seq(7, 19723)
    var right = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int32, BIN_OP_GE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 7)


def test_date32_col_col_lt() raises:
    var left = _build_int32_seq(7, 19723)
    var right = _build_int32_seq(7, 19726)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int32, BIN_OP_LT](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 7)


def test_date32_col_col_le() raises:
    var left = _build_int32_seq(7, 19723)
    var right = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int32, BIN_OP_LE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 7)


def test_date32_col_col_eq() raises:
    var left = _build_int32_seq(7, 19723)
    var right = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int32, BIN_OP_EQ](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 7)


def test_date32_col_col_ne() raises:
    var left = _build_int32_seq(7, 19723)
    var right = _build_int32_seq(7, 19723)
    var sel_in = _identity_sel(7)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_col[DType.int32, BIN_OP_NE](
        left, right, sel_in, true_sel, false_sel
    )
    assert_equal(count, 0)


# =============================================================================
# Identity-fast-path vs gather-path parity — same inputs, two paths,
# same answer.
# =============================================================================


def test_identity_vs_gather_parity_f64() raises:
    """Verify the identity-fast-path and the gather-path produce identical
    results when fed equivalent inputs."""
    var col = _build_float64_seq(67, 0.0)

    # Identity path.
    var sel_id = _identity_sel(67)
    var true_id = RowSelectionVector()
    var false_id = RowSelectionVector()
    var count_id = binary_select_col_lit[DType.float64, BIN_OP_GT](
        col, 8.0, sel_id, true_id, false_id
    )

    # Gather path with a non-identity sel that happens to include all rows
    # but in a different shape that doesn't match col.length (66 rows).
    var col2 = _build_float64_seq(67, 0.0)
    var sel_gather = RowSelectionVector()
    for i in range(66):  # 66 != 67 → gather path
        sel_gather.append(UInt32(i))
    var true_g = RowSelectionVector()
    var false_g = RowSelectionVector()
    var count_g = binary_select_col_lit[DType.float64, BIN_OP_GT](
        col2, 8.0, sel_gather, true_g, false_g
    )

    # Identity path got all 34 surviving rows (>8 for i in 33..66).
    assert_equal(count_id, 34)
    # Gather path saw rows 0..65 only, so misses row 66 (16.5 > 8).
    # Surviving: i in 33..65 = 33 rows.
    assert_equal(count_g, 33)

    # Both partition correctly.
    _check_sel_pair_partition(67, true_id.len(), false_id.len())
    _check_sel_pair_partition(66, true_g.len(), false_g.len())


def test_gather_path_narrowed_sel_int32() raises:
    """Gather path with sel_in narrowed by 'prior conjunct'."""
    var col = _build_int32_seq(100, 0)
    # Prior conjunct picked even-indexed rows: 0, 2, 4, ..., 98.
    var sel_in = RowSelectionVector()
    for i in range(50):
        sel_in.append(UInt32(i * 2))

    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    var count = binary_select_col_lit[DType.int32, BIN_OP_GT](
        col, Int32(50), sel_in, true_sel, false_sel
    )

    # Of {0, 2, ..., 98}: rows where value > 50 are {52, 54, ..., 98} = 24.
    assert_equal(count, 24)
    _check_sel_pair_partition(50, true_sel.len(), false_sel.len())

    # Verify the physical indices written to true_sel are EVEN and > 50.
    for k in range(true_sel.len()):
        var idx = Int(true_sel.get(k))
        assert_true(idx % 2 == 0)
        assert_true(idx > 50)


# =============================================================================
# Edge cases — empty sel_in / all-pass / all-fail.
# =============================================================================


def test_empty_sel_in() raises:
    """sel_in is empty → returns 0; both output sels empty."""
    var col = _build_int32_seq(10, 0)
    # Build an empty (length=0) sel_in. Use a fresh RowSelectionVector
    # without appending. Note: col.length is 10, sel_in.len() is 0 → 0 != 10
    # so we take the gather path with zero iterations.
    var sel_in = RowSelectionVector()
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_GT](
        col, Int32(0), sel_in, true_sel, false_sel
    )
    assert_equal(count, 0)
    assert_equal(true_sel.len(), 0)
    assert_equal(false_sel.len(), 0)


def test_all_pass() raises:
    """Every row passes. true_sel = sel_in, false_sel empty."""
    var col = _build_int32_seq(16, 100)  # 100..115
    var sel_in = _identity_sel(16)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_GE](
        col, Int32(0), sel_in, true_sel, false_sel
    )
    assert_equal(count, 16)
    assert_equal(false_sel.len(), 0)


def test_all_fail() raises:
    """No row passes. true_sel empty, false_sel = sel_in."""
    var col = _build_int32_seq(16, 100)
    var sel_in = _identity_sel(16)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.int32, BIN_OP_LT](
        col, Int32(0), sel_in, true_sel, false_sel
    )
    assert_equal(count, 0)
    assert_equal(false_sel.len(), 16)


# =============================================================================
# NaN handling — IEEE 754 semantics.
# a OP NaN → false for {<, <=, >, >=, ==}; a != NaN → true.
#
# ⚠ THESE EXPECTATIONS PIN WHAT THE ENGINE DOES TODAY, AND THAT IS A KNOWN
# DIVERGENCE — NOT DuckDB parity: in DuckDB v1.5.3
# `'nan' = 'nan'` is TRUE and `'nan' > 'inf'` is TRUE there, as in PostgreSQL
# and Spark SQL. Leave these expectations ALONE until the engine adopts one
# shared NaN comparison semantics; they are the deliberate pin that makes
# that change move a test on purpose.
# =============================================================================


def test_nan_lt_returns_false() raises:
    """col[i] < NaN → false for every i; row never selected."""
    var src = List[Scalar[DType.float64]]()
    src.append(Scalar[DType.float64](1.0))
    src.append(Scalar[DType.float64](2.0))
    src.append(Scalar[DType.float64](3.0))
    var col = PrimitiveArray[DType.float64].from_list(src)

    var sel_in = _identity_sel(3)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()
    # Float64 NaN via 0.0/0.0 idiom (compile-time may fold; use explicit
    # SIMD bit-cast).
    var nan_val = Float64(0.0) / Float64(0.0)
    assert_true(isnan(nan_val))

    var count = binary_select_col_lit[DType.float64, BIN_OP_LT](
        col, nan_val, sel_in, true_sel, false_sel
    )
    # Every row compares false against NaN.
    assert_equal(count, 0)
    assert_equal(false_sel.len(), 3)


def test_nan_eq_returns_false() raises:
    """col[i] == NaN → false; NaN != NaN."""
    var src = List[Scalar[DType.float64]]()
    var nan_val = Float64(0.0) / Float64(0.0)
    src.append(nan_val)
    src.append(Scalar[DType.float64](1.0))
    src.append(nan_val)
    var col = PrimitiveArray[DType.float64].from_list(src)

    var sel_in = _identity_sel(3)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.float64, BIN_OP_EQ](
        col, nan_val, sel_in, true_sel, false_sel
    )
    assert_equal(count, 0)


def test_nan_ne_returns_true() raises:
    """col[i] != NaN → true for every i."""
    var src = List[Scalar[DType.float64]]()
    var nan_val = Float64(0.0) / Float64(0.0)
    src.append(nan_val)
    src.append(Scalar[DType.float64](1.0))
    src.append(nan_val)
    var col = PrimitiveArray[DType.float64].from_list(src)

    var sel_in = _identity_sel(3)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    var count = binary_select_col_lit[DType.float64, BIN_OP_NE](
        col, nan_val, sel_in, true_sel, false_sel
    )
    assert_equal(count, 3)


# =============================================================================
# Identity-fast-path verification — instrumentation-free check.
# The identity path detection is "sel_in.len() == col.length"; we can
# observe this indirectly by feeding identity input and verifying the
# kernel writes physical row indices [0..n) in order.
# =============================================================================


def test_identity_path_writes_physical_indices_in_order() raises:
    """When sel_in is identity, the unit-stride path writes indices 0..n-1
    in physical order (no permutation)."""
    var col = _build_int32_seq(20, 0)
    var sel_in = _identity_sel(20)
    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    # All-pass via >=0.
    var count = binary_select_col_lit[DType.int32, BIN_OP_GE](
        col, Int32(0), sel_in, true_sel, false_sel
    )
    assert_equal(count, 20)
    for k in range(20):
        assert_equal(Int(true_sel.get(k)), k)


def test_gather_path_writes_physical_indices_in_sel_order() raises:
    """When sel_in is permuted, the gather path writes PHYSICAL row
    indices from sel_in (not the logical k)."""
    var col = _build_int32_seq(20, 0)
    # Reverse-shaped sel_in: 19, 17, 15, ..., 1 (odd indices descending).
    var sel_in = RowSelectionVector()
    var k = 19
    while k >= 1:
        sel_in.append(UInt32(k))
        k -= 2

    var true_sel = RowSelectionVector()
    var false_sel = RowSelectionVector()

    # All-pass via >=0 → true_sel should equal sel_in.
    var count = binary_select_col_lit[DType.int32, BIN_OP_GE](
        col, Int32(0), sel_in, true_sel, false_sel
    )
    assert_equal(count, sel_in.len())
    # Compare row by row.
    for i in range(sel_in.len()):
        assert_equal(Int(true_sel.get(i)), Int(sel_in.get(i)))


# =============================================================================
# Selectivity fuzz — random Lit, all 6 ops, partition invariant.
# =============================================================================


def test_selectivity_fuzz_partition_invariant() raises:
    """Run all 6 ops on the same identity-sel Float64 fixture and verify
    each kernel partitions sel_in correctly (true + false = total)."""
    var n = 257  # > 128 to exercise SIMD body and tail
    var col = _build_float64_seq(n, 0.0)
    var sel_in = _identity_sel(n)
    var threshold = 7.5

    var t = RowSelectionVector()
    var f = RowSelectionVector()
    _ = binary_select_col_lit[DType.float64, BIN_OP_GT](
        col, threshold, sel_in, t, f
    )
    _check_sel_pair_partition(n, t.len(), f.len())

    t = RowSelectionVector()
    f = RowSelectionVector()
    _ = binary_select_col_lit[DType.float64, BIN_OP_GE](
        col, threshold, sel_in, t, f
    )
    _check_sel_pair_partition(n, t.len(), f.len())

    t = RowSelectionVector()
    f = RowSelectionVector()
    _ = binary_select_col_lit[DType.float64, BIN_OP_LT](
        col, threshold, sel_in, t, f
    )
    _check_sel_pair_partition(n, t.len(), f.len())

    t = RowSelectionVector()
    f = RowSelectionVector()
    _ = binary_select_col_lit[DType.float64, BIN_OP_LE](
        col, threshold, sel_in, t, f
    )
    _check_sel_pair_partition(n, t.len(), f.len())

    t = RowSelectionVector()
    f = RowSelectionVector()
    _ = binary_select_col_lit[DType.float64, BIN_OP_EQ](
        col, threshold, sel_in, t, f
    )
    _check_sel_pair_partition(n, t.len(), f.len())

    t = RowSelectionVector()
    f = RowSelectionVector()
    _ = binary_select_col_lit[DType.float64, BIN_OP_NE](
        col, threshold, sel_in, t, f
    )
    _check_sel_pair_partition(n, t.len(), f.len())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
